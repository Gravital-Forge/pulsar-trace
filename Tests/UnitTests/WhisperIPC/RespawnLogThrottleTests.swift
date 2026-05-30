import Testing
import Foundation
@testable import PulsarTraceEngine

/// Covers the exponential-backoff schedule used by
/// `RemoteWindowTranscriber` to throttle the "still waiting for whisper
/// subprocess respawn" log line
/// (`docs/specs/2026-05-26-whisper-subprocess-design.md` §6).
@Suite("RespawnLogThrottle")
struct RespawnLogThrottleTests {

    @Test("default schedule doubles 5s → 10s → 20s → 40s → 80s → 160s → 320s → caps at 600s")
    func defaultDoubling() {
        var t = RespawnLogThrottle()
        let expected: [Duration] = [
            .seconds(5), .seconds(10), .seconds(20),
            .seconds(40), .seconds(80), .seconds(160),
            .seconds(320), .seconds(600), .seconds(600),
            .seconds(600),
        ]
        for e in expected {
            #expect(t.nextDelay() == e)
        }
    }

    @Test("custom initial + cap doubles and caps at the configured cap")
    func customConfig() {
        var t = RespawnLogThrottle(
            initial: .milliseconds(100),
            cap: .milliseconds(500))
        #expect(t.nextDelay() == .milliseconds(100))
        #expect(t.nextDelay() == .milliseconds(200))
        #expect(t.nextDelay() == .milliseconds(400))
        // 800ms doubles past 500ms cap → 500ms
        #expect(t.nextDelay() == .milliseconds(500))
        #expect(t.nextDelay() == .milliseconds(500))
    }

    @Test("reset() returns to the constructor's initial — not a hardcoded default")
    func resetGoesBackToInitial() {
        var t = RespawnLogThrottle(initial: .milliseconds(50))
        _ = t.nextDelay()
        _ = t.nextDelay()
        _ = t.nextDelay()
        t.reset()
        #expect(t.nextDelay() == .milliseconds(50))
    }

    @Test("default reset returns to 5s — the spec-prescribed initial")
    func defaultReset() {
        var t = RespawnLogThrottle()
        for _ in 0..<5 { _ = t.nextDelay() }
        t.reset()
        #expect(t.nextDelay() == .seconds(5))
    }
}
