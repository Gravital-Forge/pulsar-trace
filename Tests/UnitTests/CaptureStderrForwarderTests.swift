import Testing
import Foundation
import Logging
@testable import PulsarTraceEngine

/// Unit coverage of `CaptureStderrForwarder` — the line-drain that forwards the
/// capture daemon's own path-free diagnostics (prefixed `"pulsartrace-capture: "`)
/// into the engine's operational log, replacing the post-`ready` void drain.
///
/// Modeled on the real incident (rec_2026-07-30-133002): during a 62-min
/// meeting the daemon logged a microphone stall + restart attempts + recovery,
/// all discarded by the old void drain, so the operational log showed nothing.
///
/// The forwarder is driven directly via `ingest(_:)` — no live subprocess — so
/// the test is deterministic and fast. Wiring into `RecordOrchestrator.start`
/// is covered by the existing "RecordOrchestrator (record, PT-R47)" suite.
@Suite("CaptureStderrForwarder")
struct CaptureStderrForwarderTests {

    private func makeForwarder() -> (CaptureStderrForwarder, CapturingLogHandler) {
        let capture = CapturingLogHandler()
        let logger = Logger(label: LogSubsystem.capture) { _ in capture }
        // A no-op read handle stands in — the test drives `ingest` directly.
        let forwarder = CaptureStderrForwarder(
            handle: FileHandle.nullDevice, logger: logger)
        return (forwarder, capture)
    }

    @Test("forwards a prefixed diagnostic line with the prefix stripped")
    func forwardsPrefixedLineStripped() {
        let (forwarder, capture) = makeForwarder()
        forwarder.ingest(Data(
            "pulsartrace-capture: microphone stream stalled — restarting\n".utf8))
        #expect(capture.messages.contains(
            "microphone stream stalled — restarting"))
        #expect(!capture.messages.contains { $0.contains("pulsartrace-capture:") })
    }

    @Test("drops a non-prefixed line even when it embeds a path")
    func dropsNonPrefixedPathBearingLine() {
        let (forwarder, capture) = makeForwarder()
        // Arbitrary AVFoundation/CoreAudio spew may embed a full user path —
        // Hard Invariant #7 forbids that in the operational log, so any line
        // without the daemon prefix is dropped wholesale.
        forwarder.ingest(Data(
            "/Users/nobody/secret/file.wav garbage\n".utf8))
        #expect(capture.messages.isEmpty)
        #expect(!capture.messages.contains { $0.contains("/Users/nobody/secret") })
    }

    @Test("truncates a forwarded line to 512 characters")
    func truncatesLongLine() {
        let (forwarder, capture) = makeForwarder()
        let body = String(repeating: "x", count: 900)
        forwarder.ingest(Data("pulsartrace-capture: \(body)\n".utf8))
        #expect(capture.messages.count == 1)
        #expect(capture.messages.first?.count == 512)
        #expect(capture.messages.first == String(repeating: "x", count: 512))
    }

    @Test("buffers a partial line across chunk boundaries")
    func buffersAcrossChunks() {
        let (forwarder, capture) = makeForwarder()
        forwarder.ingest(Data("pulsartrace-capture: micro".utf8))
        #expect(capture.messages.isEmpty)   // no newline yet — nothing forwarded
        forwarder.ingest(Data("phone stream recovered\n".utf8))
        #expect(capture.messages == ["microphone stream recovered"])
    }

    @Test("forwards multiple lines in one chunk, mixed prefixed / not")
    func forwardsMultipleMixedLines() {
        let (forwarder, capture) = makeForwarder()
        forwarder.ingest(Data("""
        pulsartrace-capture: microphone stream stalled — restarting
        /Users/nobody/secret/file.wav garbage
        pulsartrace-capture: microphone stream recovered

        """.utf8))
        #expect(capture.messages == [
            "microphone stream stalled — restarting",
            "microphone stream recovered",
        ])
    }

    @Test("drops the carry buffer when it grows past 64 KiB without a newline")
    func dropsOverlongNewlineFreeCarry() {
        let (forwarder, capture) = makeForwarder()
        // A newline-free flood larger than the 64 KiB carry cap must be dropped
        // rather than buffered unbounded. A subsequent well-formed line still
        // forwards (buffer was cleared, not poisoned).
        forwarder.ingest(Data(String(repeating: "z", count: 70 * 1024).utf8))
        #expect(capture.messages.isEmpty)
        forwarder.ingest(Data("pulsartrace-capture: back to normal\n".utf8))
        #expect(capture.messages == ["back to normal"])
    }
}
