import Testing
@testable import PulsarTraceEngine

@Suite("AbortToken")
struct AbortTokenTests {
    @Test("starts un-cancelled, latches on cancel")
    func latches() {
        let t = AbortToken()
        #expect(t.isCancelled == false)
        t.cancel()
        #expect(t.isCancelled == true)
        t.cancel()  // idempotent
        #expect(t.isCancelled == true)
    }
}
